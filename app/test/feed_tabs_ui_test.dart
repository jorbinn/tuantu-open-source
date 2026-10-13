/// 首页顶部 Tab 改版回归：文字 Tab + 粉色指示线 + 长按「有我的」筛选 +
/// FeedItem 横拖时指示线跟手。Dio 用假 adapter，不碰真网络
/// （testWidgets + 真实本地 HTTP 会挂起，见 swipe_race_test 的教训；
/// Dio 内部有 Timer(0)，fake async 里必须推进时钟才能走完请求链）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/swipe_page.dart';
import 'package:tuantu_app/widgets/feed_media.dart';

Map<String, dynamic> _card(
  int id,
  String uploader, {
  double createdAt = 1770000000.0,
  int likes = 0,
  int comments = 0,
}) =>
    {
      'id': id,
      'thumb': '/api/asset/$id/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 0,
      'orig_name': 'IMG_$id.jpg',
      'width': 100,
      'height': 100,
      'taken_at': 1770000000,
      'created_at': createdAt,
      'uploader': uploader,
      'uploader_id': 1,
      'avatar': null,
      'mine': false,
      'likes': likes,
      'liked': false,
      'comments': comments,
      'has_live': 0,
    };

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.batches);

  final List<List<Map<String, dynamic>>> batches;
  int galleryCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object body;
    if (options.path.contains('/api/gallery')) {
      final index = galleryCalls.clamp(0, batches.length - 1);
      galleryCalls++;
      final items = batches[index];
      body = {
        'items': items,
        'cursor': items.isEmpty ? null : items.last['created_at'],
        'cursor_id': items.isEmpty ? null : items.last['id'],
      };
    } else {
      body = {'ok': true};
    }
    final bytes = utf8.encode(jsonEncode(body));
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _DeferredRefreshAdapter implements HttpClientAdapter {
  _DeferredRefreshAdapter(this.initial);

  final List<Map<String, dynamic>> initial;
  final refresh = Completer<List<Map<String, dynamic>>>();
  int galleryCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object body;
    if (options.path.contains('/api/gallery')) {
      final items = galleryCalls++ == 0 ? initial : await refresh.future;
      body = {
        'items': items,
        'cursor': items.isEmpty ? null : items.last['created_at'],
        'cursor_id': items.isEmpty ? null : items.last['id'],
      };
    } else {
      body = {'ok': true};
    }
    final bytes = utf8.encode(jsonEncode(body));
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.galleryViews, [this.galleryQueries]);
  final List<String> galleryViews;
  final List<Map<String, dynamic>>? galleryQueries;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object body;
    if (options.path.contains('/api/gallery')) {
      final view = options.queryParameters['view']?.toString() ?? 'all';
      galleryViews.add(view);
      galleryQueries?.add(Map<String, dynamic>.from(options.queryParameters));
      body = {
        'items': view == 'recommended'
            ? [_card(2, '乙'), _card(3, '丙'), _card(4, '丁')]
            : [_card(1, '甲'), _card(2, '乙'), _card(3, '丙')],
        'cursor': 1770000000.0,
        'cursor_id': 1,
      };
    } else {
      body = {'ok': true};
    }
    final bytes = utf8.encode(jsonEncode(body));
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void _wireDio(
  List<String> galleryViews, [
  List<Map<String, dynamic>>? galleryQueries,
]) {
  Api.I.configure('http://box.test:8000', 'token');
  Api.I.dio.httpClientAdapter = _FakeAdapter(galleryViews, galleryQueries);
}

_ScriptedAdapter _wireBatches(List<List<Map<String, dynamic>>> batches) {
  Api.I.configure('http://box.test:8000', 'token');
  final adapter = _ScriptedAdapter(batches);
  Api.I.dio.httpClientAdapter = adapter;
  return adapter;
}

/// 推进 fake 时钟，让 Dio 的 Timer(0) 链（请求→响应→markSeen）全部走完，
/// 否则测试收尾时报 Pending timers。
Future<void> _drainNet(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

double _indicatorLeft(WidgetTester tester) => tester
    .widget<AnimatedPositioned>(
      find.byKey(const ValueKey('feed-tab-indicator')),
    )
    .left!;

void main() {
  testWidgets('顶部 Tab 是文字 + 指示线，不再用胶囊', (tester) async {
    _wireDio([]);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SwipePage())),
    );
    await _drainNet(tester);

    expect(find.text('最近更新'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('未看过'), findsNothing);
    expect(find.text('时间线'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('feed-tab-indicator')), findsOneWidget);
  });

  testWidgets('点击 Tab 指示线平滑移到目标下方', (tester) async {
    final views = <String>[];
    _wireDio(views);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SwipePage())),
    );
    await _drainNet(tester);

    final before = _indicatorLeft(tester);
    await tester.tap(find.text('推荐'));
    await _drainNet(tester);
    expect(views, contains('recommended'));
    await tester.pumpAndSettle();
    final after = _indicatorLeft(tester);
    // 800 宽 / 4 个 Tab：指示线应右移整整一格（约 200）
    expect(after - before, closeTo(200, 8));
  });

  testWidgets('再次点击推荐会换一批，并排除最近推荐内容', (tester) async {
    final views = <String>[];
    final queries = <Map<String, dynamic>>[];
    _wireDio(views, queries);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SwipePage())),
    );
    await _drainNet(tester);

    await tester.tap(find.text('推荐'));
    await _drainNet(tester);
    await tester.tap(find.text('推荐'));
    await _drainNet(tester);

    final recommended = queries
        .where((q) => q['view'] == 'recommended')
        .toList(growable: false);
    expect(recommended, hasLength(2));
    expect(recommended[0]['seed'], isNotNull);
    expect(recommended[1]['seed'], isNot(recommended[0]['seed']));
    expect(recommended[1]['exclude'], contains('2'));
    expect(recommended[1]['exclude'], contains('3'));
    expect(recommended[1]['exclude'], contains('4'));
    expect(
      find.text('内容不多，暂时还是这些'),
      findsOneWidget,
      reason: '重复返回同一批不得说已换一批，更不能说有新作品',
    );
  });

  testWidgets('长按「有我的」：查看全部默认选中，选「只看未看过」走 mine_unseen', (tester) async {
    final views = <String>[];
    _wireDio(views);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SwipePage())),
    );
    await _drainNet(tester);

    await tester.longPress(find.text('有我的'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('查看全部'), findsOneWidget);
    expect(find.text('只看未看过'), findsOneWidget);

    CheckedPopupMenuItem<bool> menuItem(String label) =>
        tester.widget<CheckedPopupMenuItem<bool>>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(CheckedPopupMenuItem<bool>),
          ),
        );
    expect(menuItem('查看全部').checked, isTrue, reason: '默认勾选「查看全部」');
    expect(menuItem('只看未看过').checked, isFalse);

    // Text 本身不参与 hit test，事件落在菜单项 InkWell 上，属正常
    await tester.tap(find.text('只看未看过'), warnIfMissed: false);
    await _drainNet(tester);
    expect(views, contains('mine_unseen'), reason: '筛选必须由盒子的 SQL 完成');
    // 选完要切到「有我的」Tab（第 3 格）
    await tester.pumpAndSettle();
    await _drainNet(tester);
    expect(_indicatorLeft(tester), closeTo(200 * 2 + (200 - 26) / 2, 8));
  });

  testWidgets('FeedItem 横拖：指示线连续跟手、颜色渐变，松手落到相邻 Tab', (tester) async {
    _wireDio([]);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SwipePage())),
    );
    await _drainNet(tester);

    Color tabColor(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;
    final dimBefore = tabColor('推荐');

    final before = _indicatorLeft(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('feed-1'))),
    );
    final samples = <double>[];
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      samples.add(_indicatorLeft(tester));
    }
    await gesture.up();

    // 跟手：手指向左拖，横线连续向右移动，不跳变
    for (var i = 1; i < samples.length; i++) {
      expect(samples[i], greaterThan(samples[i - 1]));
      expect(samples[i] - samples[i - 1], lessThan(40));
    }
    // 颜色渐变：相邻 Tab 从暗变亮（white54→white，computeLuminance 不含
    // alpha，两者 RGB 相同，必须比 alpha）
    expect(tabColor('推荐'), isNot(dimBefore));
    expect(tabColor('推荐').a, greaterThan(dimBefore.a));

    await _drainNet(tester);
    await tester.pumpAndSettle();
    // 松手后落在下一个 Tab（推荐），不越格
    final after = _indicatorLeft(tester);
    expect(after - before, closeTo(200, 8));
    // 切到「推荐」后首图换成推荐批次的卡片2
    expect(find.text('@乙'), findsOneWidget);
    expect(find.text('@甲'), findsNothing);
  });

  testWidgets('切走再回来停留在上次那张，且不重新拉当前 Tab', (tester) async {
    final views = <String>[];
    _wireDio(views);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SwipePage())),
    );
    await _drainNet(tester);

    expect(find.text('@甲'), findsOneWidget);
    tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(2);
    await tester.pump();
    expect(find.text('@丙'), findsOneWidget);

    await tester.tap(find.text('推荐'));
    await _drainNet(tester);
    expect(views, contains('recommended'));
    expect(find.text('@乙'), findsOneWidget);

    final allHits = views.where((v) => v == 'all').length;
    await tester.tap(find.text('最近更新'));
    await tester.pump();
    await _drainNet(tester);
    expect(find.text('@丙'), findsOneWidget, reason: '应停留在切走前的那张');
    expect(find.text('@甲'), findsNothing);
    expect(
      views.where((v) => v == 'all').length,
      allHits,
      reason: '回看已浏览过的 Tab 不得重新请求，直到退出或刷新',
    );
  });

  testWidgets('首页图标触发刷新后回到第一条', (tester) async {
    final views = <String>[];
    _wireDio(views);
    final key = GlobalKey<SwipePageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SwipePage(key: key)),
      ),
    );
    await _drainNet(tester);

    tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(2);
    await tester.pump();
    expect(find.text('@丙'), findsOneWidget);

    key.currentState!.load(
      reason: FeedLoadReason.userRefresh,
      resetPosition: true,
    );
    await _drainNet(tester);
    expect(find.text('@甲'), findsOneWidget);
    expect(find.text('@丙'), findsNothing);
    expect(views.where((v) => v == 'all').length, 2);
  });

  testWidgets('首次加载和前台恢复静默更新，不弹新增提示', (tester) async {
    final key = GlobalKey<SwipePageState>();
    _wireBatches([
      [_card(1, '甲')],
      [_card(2, '新上传', createdAt: 1770000100), _card(1, '甲')],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SwipePage(key: key)),
      ),
    );
    await _drainNet(tester);

    expect(find.byType(SnackBar), findsNothing, reason: '首次加载不应弹刷新结果');
    key.currentState!.load(reason: FeedLoadReason.passiveResume);
    await _drainNet(tester);

    expect(
      key.currentState!.items.first.uploader,
      '新上传',
      reason: '后台恢复仍应更新数据，但保留当前浏览位置',
    );
    expect(find.byType(SnackBar), findsNothing, reason: '后台恢复必须静默');
  });

  testWidgets('主动刷新无变化只提示暂无更新', (tester) async {
    final key = GlobalKey<SwipePageState>();
    final same = [_card(1, '甲'), _card(2, '乙')];
    _wireBatches([same, same]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SwipePage(key: key)),
      ),
    );
    await _drainNet(tester);

    key.currentState!.load(reason: FeedLoadReason.userRefresh);
    await _drainNet(tester);

    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList();
    expect(find.text('暂无更新'), findsOneWidget, reason: '$visibleText');
    expect(find.textContaining('更新了'), findsNothing);
  });

  testWidgets('主动刷新发现新作品不用单页差集虚报条数', (tester) async {
    final key = GlobalKey<SwipePageState>();
    _wireBatches([
      [_card(1, '甲', createdAt: 1770000000)],
      [
        _card(2, '新上传', createdAt: 1770000100),
        _card(1, '甲', createdAt: 1770000000),
      ],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SwipePage(key: key)),
      ),
    );
    await _drainNet(tester);

    key.currentState!.load(reason: FeedLoadReason.userRefresh);
    await _drainNet(tester);

    expect(find.text('发现新内容'), findsOneWidget);
    expect(find.textContaining('更新了'), findsNothing);
  });

  testWidgets('点赞评论变化只说刷新完成，不冒充新作品', (tester) async {
    final key = GlobalKey<SwipePageState>();
    _wireBatches([
      [_card(1, '甲')],
      [_card(1, '甲', likes: 2, comments: 1)],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SwipePage(key: key)),
      ),
    );
    await _drainNet(tester);

    key.currentState!.load(reason: FeedLoadReason.userRefresh);
    await _drainNet(tester);

    expect(find.text('刷新完成'), findsOneWidget);
    expect(find.text('发现新内容'), findsNothing);
    expect(find.textContaining('更新了'), findsNothing);
  });

  testWidgets('分页载入旧内容不弹更新提示', (tester) async {
    final key = GlobalKey<SwipePageState>();
    final first = [
      for (var i = 40; i > 20; i--)
        _card(i, '新$i', createdAt: 1770000000.0 + i),
    ];
    final older = [
      for (var i = 20; i > 0; i--) _card(i, '旧$i', createdAt: 1770000000.0 + i),
    ];
    _wireBatches([first, older]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SwipePage(key: key)),
      ),
    );
    await _drainNet(tester);

    key.currentState!.load(reason: FeedLoadReason.pagination);
    await _drainNet(tester);

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('刷新未完成时离开页面，数据可更新但不跨页弹提示', (tester) async {
    final key = GlobalKey<SwipePageState>();
    Api.I.configure('http://box.test:8000', 'token');
    final adapter = _DeferredRefreshAdapter([_card(1, '甲')]);
    Api.I.dio.httpClientAdapter = adapter;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SwipePage(key: key)),
      ),
    );
    await _drainNet(tester);

    key.currentState!.load(reason: FeedLoadReason.userRefresh);
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SwipePage(key: key, active: false)),
      ),
    );
    adapter.refresh.complete([
      _card(2, '新上传', createdAt: 1770000100),
      _card(1, '甲'),
    ]);
    await _drainNet(tester);

    expect(key.currentState!.items.first.uploader, '新上传');
    expect(find.byType(SnackBar), findsNothing, reason: '隐藏页的旧操作不得把结果弹到当前页');
  });

  testWidgets('FeedItem 单元：拖动产生连续 progress，松手归零并触发切换', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    final progress = <double>[];
    var switched = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FeedItem(
          item: CardItem(_card(7, '小明')),
          active: true,
          saving: false,
          onZoomed: (_) {},
          onLike: () {},
          onComment: () {},
          onDownload: () {},
          onHorizontal: (_) => switched++,
          onHorizontalProgress: progress.add,
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FeedItem)),
    );
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-18, 0));
      await tester.pump();
    }
    expect(progress, isNotEmpty);
    // 连续：单调增加且步长小于一步的拖动量（18px/800px ≈ 0.02）
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThan(progress[i - 1]));
      expect(progress[i] - progress[i - 1], lessThan(0.1));
    }
    await gesture.up();
    await tester.pump();
    expect(progress.last, 0, reason: '松手后 progress 必须归零');
    expect(switched, 1, reason: '左拖超过阈值应切到下一个 Tab');
  });

  testWidgets('略斜的横滑也能切 Tab，偏竖的滑动不切', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    var switched = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FeedItem(
          item: CardItem(_card(7, '小明')),
          active: true,
          saving: false,
          onZoomed: (_) {},
          onLike: () {},
          onComment: () {},
          onDownload: () {},
          onHorizontal: (_) => switched++,
        ),
      ),
    );

    final start = tester.getCenter(find.byType(FeedItem));
    final horiz = await tester.startGesture(start);
    for (var i = 0; i < 8; i++) {
      await horiz.moveBy(const Offset(-16, -8));
      await tester.pump();
    }
    await horiz.up();
    await tester.pump();
    expect(switched, 1);

    switched = 0;
    final vert = await tester.startGesture(start);
    for (var i = 0; i < 8; i++) {
      await vert.moveBy(const Offset(-8, -20));
      await tester.pump();
    }
    await vert.up();
    await tester.pump();
    expect(switched, 0, reason: '更偏上下的滑动不得切 Tab');
  });
}
