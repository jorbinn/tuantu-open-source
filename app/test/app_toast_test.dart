import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/widgets/app_toast.dart';

void main() {
  testWidgets('toast 背景和外边距都不拦截点击或滚动，文字保持不透明', (tester) async {
    late BuildContext page;
    var taps = 0;
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return Scaffold(
              body: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: ListView.builder(
                  controller: scroll,
                  itemCount: 100,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 80, child: Text('item $i')),
                ),
              ),
            );
          },
        ),
      ),
    );
    showAppToast(page, '操作成功');
    await tester.pump();
    final background = find.byKey(const ValueKey('app-toast-background'));
    final box =
        tester.widget<DecoratedBox>(background).decoration as BoxDecoration;
    expect(box.color!.a, closeTo(0.25, 0.001));
    expect(tester.widget<Text>(find.text('操作成功')).style!.color!.a, 1);
    final center = tester.getCenter(background);
    await tester.tapAt(center);
    await tester.tapAt(Offset(30, center.dy));
    expect(taps, 2);
    await tester.dragFrom(center, const Offset(0, -160));
    await tester.pump();
    expect(scroll.offset, greaterThan(50));
    expect(find.text('操作成功'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('操作成功'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets('连续 toast 替换而不排队，旧计时器不会清掉新提示', (tester) async {
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold();
          },
        ),
      ),
    );
    showAppToast(page, '第一条');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    showAppToast(page, '第二条');
    await tester.pump();
    expect(find.text('第一条'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('第二条'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('第二条'), findsNothing);
  });

  testWidgets('页面退出和 Overlay 销毁时安全清理，不取消操作型 SnackBar', (tester) async {
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold();
          },
        ),
      ),
    );
    ScaffoldMessenger.of(page).showSnackBar(
      SnackBar(
        content: const Text('连接断开'),
        action: SnackBarAction(label: '重新连接', onPressed: () {}),
      ),
    );
    showAppToast(page, '普通提示');
    await tester.pump();
    expect(find.text('重新连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    showAppToast(page, '已销毁的页面');
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });
}
