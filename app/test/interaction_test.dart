import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/download.dart';
import 'package:tuantu_app/saver.dart';
import 'package:tuantu_app/upload_prep.dart';
import 'package:tuantu_app/pages/settings_page.dart';
import 'package:tuantu_app/pages/transfers_page.dart';
import 'package:tuantu_app/pages/upload_page.dart';
import 'package:tuantu_app/widgets/feed_action_rail.dart';
import 'package:tuantu_app/widgets/feed_media.dart';
import 'package:tuantu_app/widgets/box_image.dart';
import 'package:tuantu_app/widgets/plus_tab_button.dart';
import 'package:tuantu_app/widgets/save_progress.dart';
import 'package:tuantu_app/widgets/zoomable.dart';

List<String> feedImageUrls(WidgetTester tester) => [
      ...tester.widgetList<BoxImage>(find.byType(BoxImage)).map((e) => e.url),
      ...tester
          .widgetList<RawBoxImage>(find.byType(RawBoxImage))
          .map((e) => e.url),
    ];

void main() {
  testWidgets('中间上传按钮是带 + 的方框', (tester) async {
    final semantics = tester.ensureSemantics();
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DouyinPlusButton(onPressed: () => tapped = true),
      ),
    ));
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.bySemanticsLabel('上传'), findsOneWidget);
    await tester.tap(find.byType(DouyinPlusButton));
    expect(tapped, isTrue);
    semantics.dispose();
  });

  testWidgets('底部五个入口时上传按钮在正中间', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: SizedBox(
          height: 56,
          child: Row(
            children: [
              const Expanded(child: Center(child: Text('首页'))),
              const Expanded(child: Center(child: Text('相册'))),
              Expanded(child: DouyinPlusButton(onPressed: () {})),
              const Expanded(child: Center(child: Text('人物'))),
              const Expanded(child: Center(child: Text('我的'))),
            ],
          ),
        ),
      ),
    ));
    final plus = tester.getCenter(find.byType(DouyinPlusButton));
    final home = tester.getCenter(find.text('首页'));
    final me = tester.getCenter(find.text('我的'));
    expect(plus.dx, closeTo((home.dx + me.dx) / 2, 16));
  });

  testWidgets('查看器 Zoomable 支持双指放大拖拽', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SizedBox(
        width: 200,
        height: 200,
        child: Zoomable(
          child: ColoredBox(color: Color(0xFFFF0000)),
        ),
      ),
    ));
    expect(find.byType(Zoomable), findsOneWidget);
    final viewer = tester.widget<Zoomable>(find.byType(Zoomable));
    expect(viewer.maxScale, 4);
  });

  testWidgets('当前照片停留半秒后从缩略图切换到原文件', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    final item = CardItem({
      'id': 42,
      'thumb': '/api/asset/42/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 1,
      'orig_name': 'photo.jpg',
      'uploader': '小明',
      'liked': false,
      'mine': false,
      'width': 4000,
      'height': 3000,
      'likes': 0,
      'comments': 0,
    });
    await tester.pumpWidget(MaterialApp(
      home: FeedItem(
        item: item,
        active: true,
        saving: false,
        onZoomed: (_) {},
        onLike: () {},
        onComment: () {},
        onDownload: () {},
      ),
    ));

    expect(feedImageUrls(tester),
        contains('http://box.test:8000/api/asset/42/thumb'));
    expect(feedImageUrls(tester),
        isNot(contains('http://box.test:8000/api/asset/42/raw')));
    await tester.pump(const Duration(milliseconds: 499));
    expect(feedImageUrls(tester),
        isNot(contains('http://box.test:8000/api/asset/42/raw')));
    await tester.pump(const Duration(milliseconds: 2));
    expect(feedImageUrls(tester),
        contains('http://box.test:8000/api/asset/42/raw'));
  });

  testWidgets('没有缩略图的照片不拉原文件', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    final item = CardItem({
      'id': 42,
      'thumb': '/api/asset/42/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 0,
      'orig_name': 'photo.jpg',
      'uploader': '小明',
      'liked': false,
      'mine': false,
      'width': 4000,
      'height': 3000,
      'likes': 0,
      'comments': 0,
    });
    await tester.pumpWidget(MaterialApp(
      home: FeedItem(
        item: item,
        active: true,
        saving: false,
        onZoomed: (_) {},
        onLike: () {},
        onComment: () {},
        onDownload: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      feedImageUrls(tester),
      isNot(contains('http://box.test:8000/api/asset/42/raw')),
    );
  });

  testWidgets('非当前页即使停留也不拉原文件', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    final item = CardItem({
      'id': 42,
      'thumb': '/api/asset/42/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 1,
      'orig_name': 'photo.jpg',
      'uploader': '小明',
      'liked': false,
      'mine': false,
      'width': 4000,
      'height': 3000,
      'likes': 0,
      'comments': 0,
    });
    await tester.pumpWidget(MaterialApp(
      home: FeedItem(
        item: item,
        active: false,
        saving: false,
        onZoomed: (_) {},
        onLike: () {},
        onComment: () {},
        onDownload: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    final urls = feedImageUrls(tester);
    expect(urls, contains('http://box.test:8000/api/asset/42/thumb'));
    expect(urls, isNot(contains('http://box.test:8000/api/asset/42/raw')));
  });

  testWidgets('滑走当前页后取消原文件', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    final item = CardItem({
      'id': 42,
      'thumb': '/api/asset/42/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 1,
      'orig_name': 'photo.jpg',
      'uploader': '小明',
      'liked': false,
      'mine': false,
      'width': 4000,
      'height': 3000,
      'likes': 0,
      'comments': 0,
    });
    Widget feed({required bool active}) => MaterialApp(
          home: FeedItem(
            item: item,
            active: active,
            saving: false,
            onZoomed: (_) {},
            onLike: () {},
            onComment: () {},
            onDownload: () {},
          ),
        );
    await tester.pumpWidget(feed(active: true));
    await tester.pump(const Duration(milliseconds: 502));
    expect(
      feedImageUrls(tester),
      contains('http://box.test:8000/api/asset/42/raw'),
    );
    await tester.pumpWidget(feed(active: false));
    await tester.pump();
    expect(
      feedImageUrls(tester),
      isNot(contains('http://box.test:8000/api/asset/42/raw')),
    );
  });

  testWidgets('单张下载立即进入后台队列，不阻塞当前页面', (tester) async {
    Api.I.configure('http://127.0.0.1:1', 'token');
    Saver.alreadySavedOverride = (_) async => false;
    Saver.permissionOverride = () async => null;
    DownloadStore.I
      ..resetForTest()
      ..pauseWorkers = true;
    addTearDown(() {
      Saver.alreadySavedOverride = null;
      Saver.permissionOverride = null;
      DownloadStore.I.resetForTest();
    });
    final item = CardItem({
      'id': 7,
      'thumb': '/api/asset/7/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 1,
      'orig_name': 'keep.jpg',
      'uploader': '小明',
      'liked': false,
      'mine': true,
      'width': 10,
      'height': 10,
      'likes': 0,
      'comments': 0,
    });
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        return Scaffold(
          body: Column(
            children: [
              const Text('HOME'),
              TextButton(
                onPressed: () async => result = await queueDownload(ctx, item),
                child: const Text('SAVE'),
              ),
            ],
          ),
        );
      }),
    ));
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();
    expect(result, '已加入下载列表');
    expect(DownloadStore.I.jobs.single.assetId, 7);
    expect(DownloadStore.I.jobs.single.state, 'queued');
    expect(find.text('正在保存'), findsNothing);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('单张重复下载二次确认，取消后不进入保存进度', (tester) async {
    final item = CardItem({
      'id': 8,
      'thumb': '/api/asset/8/thumb',
      'kind': 'video',
      'ext': 'mp4',
      'has_thumb': 1,
      'orig_name': 'repeat.mp4',
      'uploader': '小明',
      'liked': false,
      'mine': true,
      'width': 10,
      'height': 10,
      'likes': 0,
      'comments': 0,
    });
    Saver.alreadySavedOverride = (_) async => true;
    Saver.permissionOverride = () async => null;
    DownloadStore.I
      ..resetForTest()
      ..pauseWorkers = true;
    addTearDown(() {
      Saver.alreadySavedOverride = null;
      Saver.permissionOverride = null;
      DownloadStore.I.resetForTest();
    });

    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        return Scaffold(
          body: TextButton(
            onPressed: () async => result = await queueDownload(ctx, item),
            child: const Text('SAVE AGAIN'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('SAVE AGAIN'));
    await tester.pump();
    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('这个视频已经下载过，是否重复保存？'), findsOneWidget);
    expect(find.text('重复保存'), findsOneWidget);
    expect(find.text('正在保存'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, '已取消保存');
    expect(DownloadStore.I.jobs, isEmpty);
  });

  test('批量保存不查重复，整批直接进入后台队列', () async {
    Api.I.configure('http://127.0.0.1:1', 'token');
    final item = CardItem({
      'id': 9,
      'thumb': '/api/asset/9/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 1,
      'orig_name': 'batch.jpg',
      'uploader': '小明',
      'liked': false,
      'mine': true,
      'width': 10,
      'height': 10,
      'likes': 0,
      'comments': 0,
    });
    Saver.alreadySavedOverride = (_) => throw StateError('批量保存不应查重');
    Saver.permissionOverride = () async => null;
    DownloadStore.I
      ..resetForTest()
      ..pauseWorkers = true;
    addTearDown(() {
      Saver.alreadySavedOverride = null;
      Saver.permissionOverride = null;
      DownloadStore.I.resetForTest();
    });

    expect(await queueDownloads([item]), 1);
    expect(DownloadStore.I.jobs.single.assetId, 9);
    expect(DownloadStore.I.jobs.single.allowDuplicate, isTrue);
  });

  testWidgets('右侧栏有头像、喜欢、评论、下载', (tester) async {
    final semantics = tester.ensureSemantics();
    final item = CardItem({
      'id': 1,
      'thumb': '',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 0,
      'orig_name': 'a.jpg',
      'uploader': '小明',
      'liked': false,
      'mine': false,
      'width': 0,
      'height': 0,
      'likes': 3,
      'comments': 2,
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FeedActionRail(
          item: item,
          onLike: () {},
          onComment: () {},
          onDownload: () {},
        ),
      ),
    ));
    expect(find.byType(CircleAvatar), findsOneWidget);
    expect(find.text('小'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byIcon(Icons.mode_comment_outlined), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('上传入口打开相册而不是所有文件', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: UploadPage()),
    ));
    expect(find.textContaining('打开相册'), findsOneWidget);
    expect(find.textContaining('选择文件'), findsNothing);
  });

  test('个人主页卡片能区分是不是自己的作品', () {
    Map<String, dynamic> card(String uploader, bool mine) => {
          'id': mine ? 1 : 2,
          'thumb': '',
          'kind': 'image',
          'ext': 'jpg',
          'has_thumb': 0,
          'orig_name': 'a.jpg',
          'uploader': uploader,
          'liked': false,
          'mine': mine,
          'width': 0,
          'height': 0,
          'likes': 0,
          'comments': 0,
        };
    expect(CardItem(card('demo', true)).isOwn, isTrue);
    expect(CardItem(card('other-user', false)).isOwn, isFalse);
  });

  test('文件名+日期去重，视频超量要确认', () {
    const a = PickedMedia(
        path: 'a.jpg',
        name: 'IMG_1.jpg',
        day: '2026-04-08',
        isVideo: false,
        size: 10);
    const b = PickedMedia(
        path: 'b.jpg',
        name: 'IMG_1.JPG',
        day: '2026-04-08',
        isVideo: false,
        size: 10);
    const c = PickedMedia(
        path: 'c.jpg',
        name: 'IMG_1.jpg',
        day: '2026-04-09',
        isVideo: false,
        size: 10);
    final left =
        excludeUploaded([a, b, c], {uploadKey('IMG_1.jpg', '2026-04-08')});
    expect(left.map((e) => e.day).toList(), ['2026-04-09']);
    expect(shouldWarnVideos(videoCount: 3, videoBytes: 10), isTrue);
    expect(
        shouldWarnVideos(videoCount: 1, videoBytes: 101 * 1024 * 1024), isTrue);
    expect(shouldWarnVideos(videoCount: 2, videoBytes: 10), isFalse);
  });

  test('保存记忆按盒子+媒体ID，删了系统照片还能再存', () {
    Map<String, dynamic> card(int id) => {
          'id': id,
          'thumb': '',
          'kind': 'image',
          'ext': 'jpg',
          'has_thumb': 1,
          'orig_name': 'IMG_1.jpg',
          'uploader': '小明',
          'liked': false,
          'mine': true,
          'width': 0,
          'height': 0,
          'likes': 0,
          'comments': 0,
          'taken_at':
              DateTime.utc(2026, 4, 8, 10, 0).millisecondsSinceEpoch ~/ 1000,
        };
    // 同名不同 ID（两个队员的同名照片）不会撞车
    final a = CardItem(card(1));
    final b = CardItem(card(2));
    expect(Saver.mediaKey(a) != Saver.mediaKey(b), isTrue);
    // 同一张照片的 key 稳定
    expect(Saver.mediaKey(a), Saver.mediaKey(CardItem(card(1))));
  });

  test('上次上传格式精确到分钟', () {
    final local = DateTime(2026, 4, 8, 14, 32);
    final t = local.millisecondsSinceEpoch / 1000;
    expect(fmtLastUpload(t), '2026年4月8日 14:32');
    expect(fmtLastUpload(null), '');
    expect(fmtLastUpload(0), '');
  });

  testWidgets('设置页有代理模式', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    expect(find.text('设置'), findsOneWidget);
    // 「作为盒子」只有安卓显示（iOS 是纯客人，假盒子已隐藏）
    if (Platform.isAndroid) {
      expect(find.text('作为盒子（团长）'), findsOneWidget);
    } else {
      expect(find.text('作为盒子（团长）'), findsNothing);
    }
    expect(find.text('代理模式'), findsOneWidget);
  });

  testWidgets('传输列表空态', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TransfersPage()));
    expect(find.text('传输列表'), findsOneWidget);
    expect(find.text('上传'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('图片识别'), findsOneWidget);
    expect(find.text('还没有传输记录'), findsOneWidget);
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(find.text('还没有下载记录'), findsOneWidget);
  });

  test('信标能读出非 .1 的盒子IP', () {
    const msg = 'TUANTU 8000 192.168.50.42 192.168.31.65';
    final ips = [
      for (final p in msg.split(RegExp(r'\s+')))
        if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(p)) p
    ];
    expect(ips, ['192.168.50.42', '192.168.31.65']);
  });
}
