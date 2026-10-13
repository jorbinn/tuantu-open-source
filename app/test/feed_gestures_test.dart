/// FeedPointerLayer 状态机：多指整轮结束、取消不确认、长按单入口、
/// 单击双击同一窗口。用假媒体目标直接喂触点。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/widgets/feed_gestures.dart';
import 'package:tuantu_app/widgets/zoomable.dart';

class _FakeTarget implements FeedGestureTarget {
  @override
  bool gestureReady = true;

  @override
  int mediaId = 1;

  @override
  Size mediaSize = const Size(800, 600);

  bool overRail = false;
  bool overScrub = false;
  bool boostSpot = false;

  @override
  bool zoomed = false;

  final taps = <Offset>[];
  final doubleTaps = <Offset>[];
  int menus = 0;
  int boostStarts = 0;
  final boostEnds = <bool>[];
  final tabDrags = <bool>[];

  @override
  bool isOverRail(Offset global) => overRail;

  @override
  bool isOverScrub(Offset global) => overScrub;

  @override
  bool isBoostSpot(Offset global) => boostSpot;

  @override
  bool get inBurstWindow => false;

  @override
  void tapMedia(Offset global) => taps.add(global);

  @override
  void doubleTapMedia(Offset global) => doubleTaps.add(global);

  @override
  void openMenu() => menus++;

  @override
  void boostStart() => boostStarts++;

  @override
  void boostMove(Offset global) {}

  @override
  void boostEnd(bool confirm) => boostEnds.add(confirm);

  @override
  void setTabDrag(bool active) => tabDrags.add(active);

  @override
  ZoomableState? mediaZoom() => null;

  @override
  void cancelGestures() {}

  @override
  void interruptScrub() {}
}

Future<FeedPointerLayerState> _pumpLayer(
  WidgetTester tester, {
  required FeedGestureSession session,
  ValueChanged<int>? onTabSwitch,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: FeedPointerLayer(
      session: session,
      onTabSwitch: onTabSwitch,
      child: const SizedBox.expand(),
    ),
  ));
  await tester.pump();
  return tester.state<FeedPointerLayerState>(find.byType(FeedPointerLayer));
}

void main() {
  testWidgets('干净的短按：320ms 后才执行单击，窗口内第二击只双击', (tester) async {
    final target = _FakeTarget();
    final session = FeedGestureSession()..activeItem = target;
    await _pumpLayer(tester, session: session);

    final first = await tester.startGesture(const Offset(400, 300));
    await first.up();
    await tester.pump();
    expect(target.taps, isEmpty, reason: '双击窗口内单击必须暂缓');

    await tester.pump(const Duration(milliseconds: 300));
    final second = await tester.startGesture(const Offset(400, 300));
    await second.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.doubleTaps, hasLength(1));
    expect(target.taps, isEmpty, reason: '确认双击后不得再执行单击');
  });

  testWidgets('280ms 间隔的第二击也算双击，不得先执行单击', (tester) async {
    final target = _FakeTarget();
    final session = FeedGestureSession()..activeItem = target;
    await _pumpLayer(tester, session: session);

    final first = await tester.startGesture(const Offset(400, 300));
    await first.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));
    final second = await tester.startGesture(const Offset(400, 300));
    await second.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.doubleTaps, hasLength(1));
    expect(target.taps, isEmpty);
  });

  testWidgets('超过双击窗口的两次点击，各自执行单击', (tester) async {
    final target = _FakeTarget();
    final session = FeedGestureSession()..activeItem = target;
    await _pumpLayer(tester, session: session);

    final first = await tester.startGesture(const Offset(400, 300));
    await first.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.taps, hasLength(1), reason: '窗口过完应执行第一次单击');

    final second = await tester.startGesture(const Offset(400, 300));
    await second.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.taps, hasLength(2));
    expect(target.doubleTaps, isEmpty);
  });

  testWidgets('本轮出现过双指后，先抬一指再移动剩余手指也不得点击或切 Tab', (tester) async {
    final target = _FakeTarget();
    final session = FeedGestureSession()..activeItem = target;
    var switched = 0;
    await _pumpLayer(tester, session: session, onTabSwitch: (_) => switched++);

    final a = await tester.startGesture(const Offset(400, 300), pointer: 1);
    await tester.pump();
    final b = await tester.startGesture(const Offset(430, 300), pointer: 2);
    await tester.pump();
    await a.up();
    await tester.pump();
    await b.moveBy(const Offset(-80, 0));
    await tester.pump();
    await b.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.taps, isEmpty, reason: '多指轮不得产生点击');
    expect(target.doubleTaps, isEmpty);
    expect(switched, 0, reason: '多指轮不得切 Tab');
    expect(target.menus, 0);
  });

  testWidgets('PointerCancel 不得执行单击，也不得确认倍速或切 Tab', (tester) async {
    final target = _FakeTarget()..boostSpot = true;
    final session = FeedGestureSession()..activeItem = target;
    var switched = 0;
    await _pumpLayer(tester, session: session, onTabSwitch: (_) => switched++);

    final g = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(target.boostStarts, 1);
    await g.cancel();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.taps, isEmpty, reason: '取消路径不得执行单击');
    expect(target.boostEnds, [false], reason: '取消不得确认倍速');
    expect(switched, 0);
  });

  testWidgets('长按 500ms 只触发菜单，不叠加单击', (tester) async {
    final target = _FakeTarget();
    final session = FeedGestureSession()..activeItem = target;
    await _pumpLayer(tester, session: session);

    final g = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(target.menus, 1, reason: '长按菜单只应有单一入口');
    expect(target.boostStarts, 0);
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.taps, isEmpty, reason: '长按轮不得再执行单击');
    expect(target.doubleTaps, isEmpty);
  });

  testWidgets('视频倍速区长按只进倍速，不打开菜单', (tester) async {
    final target = _FakeTarget()..boostSpot = true;
    final session = FeedGestureSession()..activeItem = target;
    var stopped = 0;
    session.stopPageDrag = () => stopped++;
    await _pumpLayer(tester, session: session);

    final g = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(target.boostStarts, 1);
    expect(target.menus, 0);
    expect(stopped, greaterThan(0), reason: '倍速长按必须停掉页面拖动，否则下划会翻页');
    await g.up();
    await tester.pump();
    expect(target.boostEnds, [true]);
  });

  testWidgets('倍速长按后下划不得切 Tab，只更新倍速手势', (tester) async {
    final target = _FakeTarget()..boostSpot = true;
    final session = FeedGestureSession()..activeItem = target;
    var switched = 0;
    var stopped = 0;
    session.stopPageDrag = () => stopped++;
    await _pumpLayer(tester, session: session, onTabSwitch: (_) => switched++);

    final g = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(target.boostStarts, 1);
    expect(stopped, greaterThan(0));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 30));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(switched, 0, reason: '倍速下划是锁定倍速，不得切 Tab');
    expect(target.tabDrags, isEmpty);
    expect(target.boostEnds, [true]);
  });

  testWidgets('横滑：同一根手指的起点计算，松手切 Tab 并释放锁', (tester) async {
    final target = _FakeTarget();
    final session = FeedGestureSession()..activeItem = target;
    var switched = 0;
    await _pumpLayer(tester, session: session, onTabSwitch: (_) => switched++);

    final g = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(-16, -6));
      await tester.pump();
    }
    expect(target.tabDrags, [true], reason: '横滑成立必须占用翻页');
    await g.up();
    await tester.pump();
    expect(target.tabDrags.last, isFalse, reason: '松手必须释放横滑锁');
    expect(switched, 1);
  });

  testWidgets('点击后立即滑动，取消待执行单击', (tester) async {
    final target = _FakeTarget();
    final session = FeedGestureSession()..activeItem = target;
    await _pumpLayer(tester, session: session);

    final tap = await tester.startGesture(const Offset(400, 300));
    await tap.up();
    await tester.pump();
    final drag = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 8; i++) {
      await drag.moveBy(const Offset(0, -20));
      await tester.pump();
    }
    await drag.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.taps, isEmpty);
    expect(target.doubleTaps, isEmpty);
  });

  testWidgets('放大后单指长按拖拽不弹菜单', (tester) async {
    final target = _FakeTarget()..zoomed = true;
    final session = FeedGestureSession()..activeItem = target;
    await _pumpLayer(tester, session: session);

    final g = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 200));
    await g.moveBy(const Offset(12, 24));
    await tester.pump(const Duration(milliseconds: 500));
    await g.moveBy(const Offset(20, 30));
    await tester.pump();
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.menus, 0, reason: '放大后单指只拖细节，不得弹出菜单');
    expect(target.boostStarts, 0);
    expect(target.taps, isEmpty);
  });

  testWidgets('落在侧栏上的按下不触发媒体单击或长按', (tester) async {
    final target = _FakeTarget()..overRail = true;
    final session = FeedGestureSession()..activeItem = target;
    await _pumpLayer(tester, session: session);

    final g = await tester.startGesture(const Offset(760, 300));
    await tester.pump(const Duration(milliseconds: 600));
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.taps, isEmpty);
    expect(target.menus, 0);
  });

  testWidgets('统一取消入口清理待执行单击', (tester) async {
    final target = _FakeTarget();
    final session = FeedGestureSession()..activeItem = target;
    final layer = await _pumpLayer(tester, session: session);

    final g = await tester.startGesture(const Offset(400, 300));
    await g.up();
    await tester.pump();
    layer.cancelRound();
    await tester.pump(const Duration(milliseconds: 400));
    expect(target.taps, isEmpty);
  });
}
