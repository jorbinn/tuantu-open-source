import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/widgets/raw_image.dart';

void main() {
  setUp(RawImageGate.reset);
  tearDown(RawImageGate.reset);

  test('在途原图有上限，滑走释放后才能再开一张', () {
    expect(RawImageGate.tryAcquire('http://box/a'), isTrue);
    expect(RawImageGate.tryAcquire('http://box/b'), isFalse);
    expect(RawImageGate.inFlightCount, 1);
    RawImageGate.release('http://box/a');
    expect(RawImageGate.tryAcquire('http://box/b'), isTrue);
  });

  test('回到刚看过的图可以命中小缓存，不必再占在途槽', () {
    RawImageGate.remember('http://box/a', Uint8List.fromList([1, 2, 3]));
    expect(RawImageGate.cached('http://box/a'), isNotNull);
    expect(RawImageGate.tryAcquire('http://box/b'), isTrue);
    expect(RawImageGate.inFlightCount, 1);
  });

  test('取消会打断已建立连接但迟迟不结束的下载', () async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      server.listen((req) async {
        if (!started.isCompleted) started.complete();
        req.response.bufferOutput = false;
        req.response.contentLength = 8 * 1024 * 1024;
        req.response.write('x' * 1024);
        await Future<void>.delayed(const Duration(seconds: 8));
        try {
          await req.response.close();
        } catch (_) {}
      });
      final getter = CancellableHttpGet();
      final future = getter.get('http://127.0.0.1:${server.port}/raw');
      await started.future.timeout(const Duration(seconds: 2));
      getter.cancel();
      final bytes = await future.timeout(const Duration(seconds: 2));
      expect(bytes, isNull);
      expect(RawImageGate.inFlightCount, 0);
    } finally {
      await server?.close(force: true);
      HttpOverrides.global = saved;
    }
  });
}
