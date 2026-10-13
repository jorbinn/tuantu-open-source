import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/album_prep.dart';

void main() {
  test('取消后不再回退 originFile / file', () async {
    final calls = <String>[];
    final file = await resolveAlbumFile(
      cancelled: () => true,
      loadFile: () async {
        calls.add('load');
        throw Exception('cancelled');
      },
      originFile: () async {
        calls.add('origin');
        return File('/tmp/origin.jpg');
      },
      file: () async {
        calls.add('file');
        return File('/tmp/file.jpg');
      },
    );
    expect(file, isNull);
    expect(calls, isEmpty);
  });

  test('loadFile 失败后若未取消才回退', () async {
    var cancelled = false;
    final file = await resolveAlbumFile(
      cancelled: () => cancelled,
      loadFile: () async => null,
      originFile: () async => File('/tmp/origin.jpg'),
      file: () async => File('/tmp/file.jpg'),
    );
    expect(file?.path, '/tmp/origin.jpg');
  });

  test('旧一轮 finally 不能清掉新一轮', () {
    expect(
      shouldClearPrepSession(finishedGen: 1, currentGen: 2),
      isFalse,
    );
    expect(
      shouldClearPrepSession(finishedGen: 2, currentGen: 2),
      isTrue,
    );
  });

  test('实况导出静图和动态必须同一版本，编辑版优先', () async {
    final calls = <String>[];
    final pair = await resolveLiveExportPair(
      cancelled: () => false,
      loadStill: ({required isOrigin}) async {
        calls.add('still-${isOrigin ? 'orig' : 'edit'}');
        if (!isOrigin) return File('/tmp/edit.jpg');
        return File('/tmp/orig.jpg');
      },
      loadVideo: ({required isOrigin}) async {
        calls.add('video-${isOrigin ? 'orig' : 'edit'}');
        if (!isOrigin) return File('/tmp/edit.mov');
        return File('/tmp/orig.mov');
      },
    );
    expect(pair?.still.path, '/tmp/edit.jpg');
    expect(pair?.video.path, '/tmp/edit.mov');
    expect(calls, ['still-edit', 'video-edit']);
  });

  test('编辑版动态缺失时，整套退回原片，不混用两个版本', () async {
    final pair = await resolveLiveExportPair(
      cancelled: () => false,
      loadStill: ({required isOrigin}) async =>
          File(isOrigin ? '/tmp/orig.jpg' : '/tmp/edit.jpg'),
      loadVideo: ({required isOrigin}) async =>
          isOrigin ? File('/tmp/orig.mov') : null,
    );
    expect(pair?.still.path, '/tmp/orig.jpg');
    expect(pair?.video.path, '/tmp/orig.mov');
  });

  test('本机没有原片就当 iCloud，不要开始导出', () {
    expect(shouldSkipIcloudOrigin(originLocal: false), isTrue);
    expect(shouldSkipIcloudOrigin(originLocal: true), isFalse);
    expect(shouldSkipIcloudOrigin(originLocal: null), isFalse);
  });

  test('超时或取消后不再回退 originFile / file', () {
    expect(
        shouldFallbackAfterLoad(cancelled: true, timedOut: false), isFalse);
    expect(
        shouldFallbackAfterLoad(cancelled: false, timedOut: true), isFalse);
    expect(
        shouldFallbackAfterLoad(cancelled: false, timedOut: false), isTrue);
  });

  test('loadFile 超时后不再回退 originFile', () async {
    var originCalled = false;
    var fileCalled = false;
    final hanging = Completer<File?>();
    final file = await resolveAlbumFile(
      cancelled: () => false,
      loadFile: () => hanging.future,
      originFile: () async {
        originCalled = true;
        return File('/tmp/origin.jpg');
      },
      file: () async {
        fileCalled = true;
        return File('/tmp/file.jpg');
      },
      stepTimeout: const Duration(milliseconds: 30),
    );
    if (!hanging.isCompleted) hanging.complete(null);
    expect(file, isNull);
    expect(originCalled, isFalse);
    expect(fileCalled, isFalse);
  });

  test('withTimeoutOrNull 不会把挂起的 future 一直等下去', () async {
    final hanging = Completer<File?>();
    final out = await withTimeoutOrNull(
      hanging.future,
      timeout: const Duration(milliseconds: 20),
    );
    if (!hanging.isCompleted) hanging.complete(null);
    expect(out, isNull);
  });

  test('取消只删本轮写出的预览，不碰别人的文件', () async {
    final dir = Directory.systemTemp.createTempSync('tuantu_prep_');
    final mine = File('${dir.path}/mine.jpg')..writeAsStringSync('a');
    final other = File('${dir.path}/other.jpg')..writeAsStringSync('b');
    final session = AlbumPrepSession(1)..rememberCreated(mine.path);
    await session.cleanupCreated();
    expect(mine.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
    dir.deleteSync(recursive: true);
  });

  test('导出预算：本机有原片给足，iCloud 在线等下载，离线不等', () {
    final local = prepLoadBudget(locallyAvailable: true, online: false);
    expect(local, isNotNull);
    expect(local!.inSeconds, greaterThanOrEqualTo(60));
    expect(
      prepLoadBudget(locallyAvailable: false, online: true),
      isNotNull,
    );
    expect(
      prepLoadBudget(locallyAvailable: false, online: false),
      isNull,
    );
  });

  test('withPrepBudget：超时和抛错都按「没拿到」处理', () async {
    final slow = withPrepBudget(
      Future<int>.delayed(const Duration(seconds: 5), () => 1),
      const Duration(milliseconds: 50),
    );
    expect(await slow, isNull);
    expect(
      await withPrepBudget(Future<int>.value(2), const Duration(seconds: 1)),
      2,
    );
    expect(
      await withPrepBudget(Future<int>.error('x'), const Duration(seconds: 1)),
      isNull,
    );
    expect(
      await withPrepBudget<int>(
        Future<int>.delayed(
            const Duration(seconds: 5), () => throw StateError('late')),
        const Duration(milliseconds: 30),
      ),
      isNull,
    );
    // 预算为 null 时不等待直接放弃。
    expect(
      await withPrepBudget<int>(Future<int>.value(3), null),
      isNull,
    );
  });

  test('withPrepBudget：预算为零立即放弃慢任务', () async {
    final r = withPrepBudget(
      Completer<int>().future,
      Duration.zero,
    );
    expect(await r, isNull);
  });

  test('probeInternetOnline：可达返回 true，拒连返回 false', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = 200;
      await req.response.close();
    });
    final ok = await probeInternetOnline(
      probeUrl: Uri.parse('http://127.0.0.1:${server.port}/probe'),
    );
    expect(ok, isTrue);
    final bad = await probeInternetOnline(
      probeUrl: Uri.parse('http://127.0.0.1:1/probe'),
      timeout: const Duration(seconds: 2),
    );
    expect(bad, isFalse);
    await server.close(force: true);
  });
}
