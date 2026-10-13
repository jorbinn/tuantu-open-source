import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';

void main() {
  late Duration savedInteractive;
  late Duration savedList;
  late int savedAttempts;

  setUp(() {
    savedInteractive = Api.interactiveTimeout;
    savedList = Api.listTimeout;
    savedAttempts = Api.listAttempts;
    Api.interactiveTimeout = const Duration(milliseconds: 250);
    Api.listTimeout = const Duration(milliseconds: 250);
    Api.listAttempts = 1;
  });

  tearDown(() {
    Api.interactiveTimeout = savedInteractive;
    Api.listTimeout = savedList;
    Api.listAttempts = savedAttempts;
  });

  test('重新配置盒子会关闭旧连接池', () {
    Api.I.configure('http://127.0.0.1:18001', 'old');
    final previous = Api.I.dio;
    Api.I.configure('http://127.0.0.1:18002', 'new');

    expect(Api.I.dio, isNot(same(previous)));
    expect(
      () => previous.get('/api/status'),
      throwsA(isA<DioException>()),
      reason: '旧盒子的 keep-alive 与在途请求必须随会话切换释放',
    );
  });

  test('已建立连接但不回包时，点赞不会卡到全局十分钟', () async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      // 接受连接后故意不写响应。
      await Future<void>.delayed(const Duration(seconds: 8));
      try {
        await req.response.close();
      } catch (_) {}
    });
    Api.I.configure('http://127.0.0.1:${server.port}', 'tok');
    final sw = Stopwatch()..start();
    await expectLater(Api.I.like(1, liked: true), throwsA(anything));
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    await server.close(force: true);
    HttpOverrides.global = saved;
  });

  test('加入盒子同样使用交互超时，且不会自动连着重试', () async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var hits = 0;
    server.listen((req) async {
      hits++;
      await Future<void>.delayed(const Duration(seconds: 8));
      try {
        await req.response.close();
      } catch (_) {}
    });
    final sw = Stopwatch()..start();
    final err = await Api.I.join('http://127.0.0.1:${server.port}', '小明', '');
    sw.stop();
    expect(err, isNotNull);
    expect(hits, 1);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    await server.close(force: true);
    HttpOverrides.global = saved;
  });
}
