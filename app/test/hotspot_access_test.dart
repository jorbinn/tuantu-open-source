import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tuantu_app/hotspot_access.dart';
import 'package:tuantu_app/pages/connect_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/hotspot');
  final bridge = HotspotAccess(channel: channel, supported: true);
  const profile = HotspotProfile('TripTest', 'test-only-password');
  final calls = <String>[];
  var enabled = false;
  var connected = false;
  String? currentSsid = 'TripTest';
  var joinResult = 'permission_denied';
  Completer<String>? pending;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    enabled = false;
    connected = false;
    currentSsid = 'TripTest';
    pending = null;
    joinResult = 'permission_denied';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'state':
          return {
            'enabled': enabled,
            'connected': connected,
            'ssid': connected ? currentSsid : null
          };
        case 'join':
          if (joinResult == 'connected') {
            connected = true;
            currentSsid = 'TripTest';
          }
          return pending == null ? joinResult : pending!.future;
        default:
          return null;
      }
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('profile validation and diagnostics never reveal passphrase', () {
    expect(profile.available, true);
    expect(profile.toString(), isNot(contains(profile.passphrase)));
    expect(const HotspotProfile('', '12345678').available, false);
    expect(const HotspotProfile('trip', 'short').available, false);
    expect(HotspotProfile('旅' * 11, '12345678').available, false);
  });

  test('unsupported platforms return unknown, not fake Wi-Fi off', () async {
    final unsupported = HotspotAccess(channel: channel, supported: false);
    expect((await unsupported.state()).known, false);
    expect(await unsupported.join(profile), 'manual');
    expect(calls, isEmpty);
  });

  test('trip discovery requires matching SSID or system-approved hidden SSID',
      () {
    expect(
        const WifiState(known: true, connected: true, ssid: 'TripTest')
            .canDiscover(profile),
        true);
    expect(
        const WifiState(known: true, connected: true, ssid: '"TripTest"')
            .canDiscover(profile),
        true);
    expect(
        const WifiState(known: true, connected: true, ssid: 'Other')
            .canDiscover(profile, targetApproved: true),
        false);
    expect(const WifiState(known: true, connected: true).canDiscover(profile),
        false);
    expect(
        const WifiState(known: true, connected: true, ssid: '<unknown ssid>')
            .canDiscover(profile, targetApproved: true),
        true);
    expect(
        const WifiState(known: true).canDiscover(profile, targetApproved: true),
        false);
    expect(const WifiState().canDiscover(profile), false);
    expect(const WifiState().canDiscover(const HotspotProfile('', '')), true);
  });

  test('missing or failed native bridge safely returns unknown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect((await bridge.state()).known, false);
    expect(await bridge.join(profile), 'unavailable');
  });

  Widget page() => MaterialApp(
      home: ConnectPage(
          hotspotProfile: profile,
          hotspotAccess: bridge,
          probeOverride: (_) async => true));

  testWidgets(
      'system join success still probes box and asks first-time nickname exactly once',
      (tester) async {
    enabled = true;
    joinResult = 'connected';
    SharedPreferences.setMockInitialValues(
        {'base': 'http://192.168.20.34:8000'});
    var probes = 0;
    await tester.pumpWidget(MaterialApp(
        home: ConnectPage(
      hotspotProfile: profile,
      hotspotAccess: bridge,
      probeOverride: (_) async {
        probes++;
        return true;
      },
    )));
    await tester.pumpAndSettle();
    expect(probes, 1);
    expect(calls.where((e) => e == 'join'), hasLength(1));
    expect(find.widgetWithText(TextField, '你的名字（如：小明）'), findsOneWidget);
    expect(find.text('进入相册'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'already connected Wi-Fi and reachable box never prompts to join again',
      (tester) async {
    enabled = true;
    connected = true;
    SharedPreferences.setMockInitialValues(
        {'base': 'http://192.168.20.34:8000'});
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('join')));
    expect(find.text('进入相册'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Wi-Fi off stops discovery and offers settings without requesting join',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('请连接 Wi-Fi：TripTest'), findsOneWidget);
    expect(calls, isNot(contains('join')));
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('手动'), findsNothing);
    expect(find.textContaining('复制'), findsNothing);
    expect(find.textContaining('继续'), findsNothing);
    expect(find.textContaining('代理'), findsNothing);
    await tester.tap(find.text('打开 Wi-Fi'));
    await tester.pump();
    expect(calls, contains('openSettings'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'declined consent never loops on resume; explicit retry may ask again',
      (tester) async {
    enabled = true;
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('请在系统 Wi-Fi 中连接 TripTest'), findsOneWidget);
    expect(calls.where((e) => e == 'join'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls.where((e) => e == 'join'), hasLength(1));
    await tester.tap(find.text('打开 Wi-Fi'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(calls.where((e) => e == 'join'), hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'correct Wi-Fi continues automatically without a resume event or continue button',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'base': 'http://192.168.20.34:8000'});
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    enabled = true;
    connected = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('进入相册'), findsOneWidget);
    expect(find.text('打开 Wi-Fi'), findsNothing);
    expect(calls, isNot(contains('join')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('turning Wi-Fi on automatically requests the target once',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'base': 'http://192.168.20.34:8000'});
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    enabled = true;
    joinResult = 'connected';
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(calls.where((e) => e == 'join'), hasLength(1));
    expect(find.text('进入相册'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'wrong Wi-Fi never probes saved address even when that box would answer',
      (tester) async {
    enabled = true;
    connected = true;
    currentSsid = 'Other';
    SharedPreferences.setMockInitialValues(
        {'base': 'http://192.168.20.34:8000'});
    var probes = 0;
    await tester.pumpWidget(MaterialApp(
        home: ConnectPage(
      hotspotProfile: profile,
      hotspotAccess: bridge,
      probeOverride: (_) async {
        probes++;
        return true;
      },
    )));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(probes, 0);
    expect(calls.where((e) => e == 'join'), hasLength(1));
    expect(find.text('进入相册'), findsNothing);
    currentSsid = 'TripTest';
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(probes, 1);
    expect(find.text('进入相册'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'background stops checks; returning on correct Wi-Fi continues once',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'base': 'http://192.168.20.34:8000'});
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final count = calls.length;
    enabled = connected = true;
    await tester.pump(const Duration(seconds: 10));
    expect(calls.length, count);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('进入相册'), findsOneWidget);
    final done = calls.length;
    await tester.pump(const Duration(seconds: 10));
    expect(calls.length, done);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disposed Wi-Fi waiting page stops polling', (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    final count = calls.length;
    await tester.pump(const Duration(seconds: 10));
    expect(calls.length, count);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden SSID requires target approval before any box probe',
      (tester) async {
    enabled = connected = true;
    currentSsid = null;
    SharedPreferences.setMockInitialValues(
        {'base': 'http://192.168.20.34:8000'});
    var probes = 0;
    await tester.pumpWidget(MaterialApp(
        home: ConnectPage(
      hotspotProfile: profile,
      hotspotAccess: bridge,
      probeOverride: (_) async {
        probes++;
        return true;
      },
    )));
    await tester.pumpAndSettle();
    expect(calls.where((e) => e == 'join'), hasLength(1));
    expect(probes, 0);
    expect(find.text('进入相册'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('small screen with keyboard keeps nickname submission reachable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    enabled = connected = true;
    SharedPreferences.setMockInitialValues(
        {'base': 'http://192.168.20.34:8000'});
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('进入相册'));
    expect(find.text('进入相册'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'leaving while system consent is pending cancels pending work; late result ignored',
      (tester) async {
    enabled = true;
    pending = Completer<String>();
    await tester.pumpWidget(page());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls, contains('join'));
    await tester.pumpWidget(const SizedBox());
    pending!.complete('connected');
    await tester.pump();
    expect(calls, contains('cancelPending'));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'explicit address joins another Wi-Fi without forcing the bundled hotspot',
      (tester) async {
    final probes = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: ConnectPage(
      hotspotProfile: profile,
      hotspotAccess: bridge,
      probeOverride: (base) async {
        probes.add(base);
        return true;
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('输入盒子地址'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '172.20.10.1');
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(probes, ['http://172.20.10.1:8000']);
    expect(calls, isNot(contains('join')));
    expect(find.text('进入相册'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual entry rejects localhost without probing it',
      (tester) async {
    final probes = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: ConnectPage(
      hotspotProfile: profile,
      hotspotAccess: bridge,
      probeOverride: (base) async {
        probes.add(base);
        return true;
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('输入盒子地址'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '127.0.0.1:8000');
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(find.text('请填写团长设置中显示的局域网地址'), findsOneWidget);
    expect(probes, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
