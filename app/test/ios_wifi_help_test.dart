import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/hotspot_access.dart';
import 'package:tuantu_app/widgets/ios_wifi_help.dart';

void main() {
  testWidgets('unconfigured iOS explains Wi-Fi steps without opening app settings', (tester) async {
    var retries = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: IosWifiHelp(
      onRetry: () => retries++,
    ))));
    expect(find.text('打开设置'), findsNothing);
    await tester.tap(find.text('如何连接 Wi-Fi'));
    await tester.pumpAndSettle();
    expect(find.textContaining('主屏幕'), findsOneWidget);
    expect(find.textContaining('「设置」→「Wi-Fi」'), findsOneWidget);
    expect(retries, 0);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('configured iOS retries system join only on explicit tap; help does not join', (tester) async {
    const channel = MethodChannel('test/ios-wifi-help');
    const profile = HotspotProfile('TripTest', 'test-password');
    final bridge = HotspotAccess(channel: channel, supported: true);
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return 'permission_denied';
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: IosWifiHelp(
      ssid: profile.ssid,
      onRetry: () { bridge.join(profile); },
    ))));
    expect(calls, isEmpty);
    await tester.tap(find.text('连接 TripTest'));
    await tester.pumpAndSettle();
    expect(calls, ['join']);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, ['join']);
    await tester.tap(find.text('如何手动连接 Wi-Fi'));
    await tester.pumpAndSettle();
    expect(find.textContaining('「TripTest」'), findsOneWidget);
    expect(calls, ['join']);
    expect(find.textContaining(profile.passphrase), findsNothing);
  });
}
