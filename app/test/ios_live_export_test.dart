import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/album_prep.dart';
import 'package:tuantu_app/ios_live_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.tuantu/live_photo');
  final calls = <MethodCall>[];
  late Completer<Map<String, String>?> pending;
  setUp(() {
    calls.clear();
    pending = Completer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'exportPair') return pending.future;
      return null;
    });
  });
  tearDown(() {
    if (!pending.isCompleted) pending.complete(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('取消不等待 iCloud 原生回调，并取消同一个请求', () async {
    final session = AlbumPrepSession(1);
    final export = exportIosLive('synthetic-asset', session: session);
    await Future<void>.delayed(Duration.zero);
    session.cancel();
    expect(await export.timeout(const Duration(seconds: 1)), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['exportPair', 'cancelExport']);
    expect(calls[1].arguments['requestId'], calls[0].arguments['requestId']);
    // A late native success does not re-enter the cancelled selection.
    pending
        .complete({'still': '/synthetic/still', 'video': '/synthetic/video'});
  });
  test('无回调到期后释放等待并请求原生清理', () async {
    expect(
        await exportIosLive('synthetic',
            session: AlbumPrepSession(2),
            budget: const Duration(milliseconds: 20)),
        isNull);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'cancelExport');
  });
  test('成功交接后确认所有权，取消前已取消的会话不开始导出', () async {
    final cancelled = AlbumPrepSession(3)..cancel();
    expect(await exportIosLive('synthetic', session: cancelled), isNull);
    expect(calls, isEmpty);
    final request = exportIosLive('synthetic', session: AlbumPrepSession(4));
    pending
        .complete({'still': '/synthetic/still', 'video': '/synthetic/video'});
    expect((await request)!['video'], '/synthetic/video');
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'ackExport');
  });
}
