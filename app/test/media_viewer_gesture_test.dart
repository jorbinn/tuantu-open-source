/// 大图手势：双指刚落下锁翻页，取消/缩回后恢复；PageView 锁在同步标志上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/widgets/zoomable.dart';

void main() {
  test('PagingLockPhysics 同步锁住用户滚动', () {
    final lock = ValueNotifier(false);
    final physics = PagingLockPhysics(lock: lock);
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 800,
      pixels: 0,
      viewportDimension: 400,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    expect(physics.shouldAcceptUserOffset(metrics), isTrue);
    expect(physics.applyPhysicsToUserOffset(metrics, 24), isNot(0));
    lock.value = true;
    expect(physics.shouldAcceptUserOffset(metrics), isFalse);
    expect(physics.applyPhysicsToUserOffset(metrics, 24), 0);
    expect(physics.createBallisticSimulation(metrics, 800), isNull);
    lock.value = false;
    final far = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 800,
      pixels: 24,
      viewportDimension: 400,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    expect(physics.targetPixelsFor(far, 0), 400,
        reason: '划过约 5% 屏高就应翻到下一页');
    final near = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 800,
      pixels: 12,
      viewportDimension: 400,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    expect(physics.targetPixelsFor(near, 0), 0);
    final pastHalf = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 800,
      pixels: 220,
      viewportDimension: 400,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    expect(physics.targetPixelsFor(pastHalf, 0), 400,
        reason: '过半屏不得算反弹回本页');

    final jitter = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 800,
      pixels: 16,
      viewportDimension: 400,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    expect(
      physics.targetPixelsFor(jitter, 0, dragStartPixels: 0),
      0,
      reason: '从 0 拖过 5% 再抖回 4%，净位移不足 5%，应留在本页',
    );
    expect(
      physics.targetPixelsFor(
        FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 800,
          pixels: 80,
          viewportDimension: 400,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1,
        ),
        0,
        dragStartPixels: 0,
      ),
      400,
      reason: '整轮净位移超过 5% 应翻到下一页',
    );
    lock.dispose();
  });

  testWidgets('双指落下立刻通知放大锁，指针取消后恢复翻页', (tester) async {
    final locks = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 500,
            child: Zoomable(
              onZoomed: locks.add,
              child: const ColoredBox(color: Color(0xFFFF0000)),
            ),
          ),
        ),
      ),
    ));

    final center = tester.getCenter(find.byType(Zoomable));
    final first = await tester.startGesture(
      center + const Offset(-24, 0),
      pointer: 1,
    );
    await tester.pump();
    expect(locks.where((e) => e), isEmpty, reason: '单指按下不能锁翻页，否则上下滑会失灵');

    final second = await tester.startGesture(
      center + const Offset(24, 0),
      pointer: 2,
    );
    await tester.pump();
    expect(locks.last, isTrue, reason: '第二指落下必须锁住上下翻页');

    await first.cancel();
    await second.cancel();
    await tester.pump();
    expect(locks.last, isFalse, reason: '指针取消且未放大时应交还翻页');
  });

  testWidgets('单指拖动不会误报放大', (tester) async {
    final locks = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 500,
            child: Zoomable(
              onZoomed: locks.add,
              child: const ColoredBox(color: Color(0xFF00FF00)),
            ),
          ),
        ),
      ),
    ));
    final center = tester.getCenter(find.byType(Zoomable));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(locks.where((e) => e), isEmpty, reason: '单指上下滑不得锁翻页');
  });

  testWidgets('单指按住数秒后再落下第二指仍能放大', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 500,
            child: Zoomable(
              child: ColoredBox(color: Color(0xFF9900FF)),
            ),
          ),
        ),
      ),
    ));
    final center = tester.getCenter(find.byType(Zoomable));
    final first = await tester.startGesture(
      center + const Offset(-20, 0),
      pointer: 1,
    );
    await tester.pump(const Duration(seconds: 3));
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 2,
    );
    await tester.pump();
    await first.moveBy(const Offset(-40, 0));
    await second.moveBy(const Offset(40, 0));
    await tester.pump();
    final state = tester.state<ZoomableState>(find.byType(Zoomable));
    expect(
      state.controller.value.getMaxScaleOnAxis(),
      greaterThan(1.05),
      reason: '先后落指也必须能捏合，不能要求两指同时碰到屏幕',
    );
    await first.up();
    await second.up();
  });

  test('横滑轴向约 45 度即可锁定，不必标准水平', () {
    expect(feedDecideAxis(4, 2), FeedSwipeAxis.undecided);
    expect(feedDecideAxis(20, 8), FeedSwipeAxis.horizontal);
    expect(feedDecideAxis(20, 20), FeedSwipeAxis.horizontal);
    expect(feedDecideAxis(12, 24), FeedSwipeAxis.vertical);
    expect(feedDecideAxis(-30, 10), FeedSwipeAxis.horizontal);
    expect(feedTabSwitchPx, 45);
  });

  testWidgets('双指拉开后实际放大', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 500,
            child: Zoomable(
              child: ColoredBox(color: Color(0xFF0000FF)),
            ),
          ),
        ),
      ),
    ));
    final center = tester.getCenter(find.byType(Zoomable));
    final a =
        await tester.startGesture(center + const Offset(-20, 0), pointer: 1);
    final b =
        await tester.startGesture(center + const Offset(20, 0), pointer: 2);
    await tester.pump();
    await a.moveBy(const Offset(-40, 0));
    await b.moveBy(const Offset(40, 0));
    await tester.pump();
    final state = tester.state<ZoomableState>(find.byType(Zoomable));
    expect(state.controller.value.getMaxScaleOnAxis(), greaterThan(1.05));
    await a.up();
    await b.up();
  });

  testWidgets('双指保持间距平移时，画面跟随中心点', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 500,
            child: Zoomable(
              child: ColoredBox(color: Color(0xFF00AAFF)),
            ),
          ),
        ),
      ),
    ));
    final center = tester.getCenter(find.byType(Zoomable));
    final a =
        await tester.startGesture(center + const Offset(-30, 0), pointer: 1);
    final b =
        await tester.startGesture(center + const Offset(30, 0), pointer: 2);
    await tester.pump();
    await a.moveBy(const Offset(-50, 0));
    await b.moveBy(const Offset(50, 0));
    await tester.pump();
    final state = tester.state<ZoomableState>(find.byType(Zoomable));
    final beforeX = state.controller.value.storage[12];
    final beforeY = state.controller.value.storage[13];
    await a.moveBy(const Offset(0, 40));
    await b.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(
      state.controller.value.storage[13] - beforeY,
      greaterThan(8),
      reason: '双指平移必须带动画面，不能只按间距缩放',
    );
    expect(state.controller.value.storage[12], closeTo(beforeX, 6));
    await a.up();
    await b.up();
  });
}
