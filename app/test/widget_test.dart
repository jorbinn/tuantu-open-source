// 冒烟：App 根组件能构建（未登录态 → 连接页）。
import 'package:flutter_test/flutter_test.dart';

import 'package:tuantu_app/main.dart';

void main() {
  testWidgets('未登录时展示连接页', (WidgetTester tester) async {
    await tester.pumpWidget(const TuantuApp(loggedIn: false));
    await tester.pump();
    expect(find.text('团 图'), findsOneWidget);
  });
}
