/// 相册全屏查看器：上下滑切图，关闭后返回最后浏览的媒体 id。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/feed_viewer_page.dart';

Map<String, dynamic> _card(int id, String uploader) => {
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
      'uploader': uploader,
      'uploader_id': 1,
      'avatar': null,
      'mine': false,
      'likes': 0,
      'liked': false,
      'comments': 0,
      'has_live': 0,
    };

void main() {
  testWidgets('相册查看器上下滑，关闭后返回当前媒体 id', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    final items = [
      CardItem(_card(11, '甲')),
      CardItem(_card(12, '乙')),
      CardItem(_card(13, '丙')),
    ];
    int? viewed;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            viewed = await FeedViewerPage.open(
              ctx,
              items: items,
              initialIndex: 0,
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final pager = tester
        .widget<PageView>(find.byKey(const ValueKey('feed-viewer-pager')));
    expect(pager.scrollDirection, Axis.vertical);
    expect(find.text('@甲'), findsOneWidget);
    expect(find.text('@丁'), findsNothing);

    pager.controller!.jumpToPage(2);
    await tester.pump();
    expect(find.text('@丙'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(viewed, 13);
  });

  test('无集合变化时不因返回而重定位来源列表', () {
    expect(
      shouldRevealSource(
        openedId: 11,
        viewedId: 11,
        openedStillExists: true,
      ),
      isFalse,
    );
    expect(
      shouldRevealSource(
        openedId: 11,
        viewedId: 13,
        openedStillExists: true,
      ),
      isTrue,
    );
    expect(
      shouldRevealSource(
        openedId: 11,
        viewedId: 12,
        openedStillExists: false,
      ),
      isTrue,
    );
  });
}
