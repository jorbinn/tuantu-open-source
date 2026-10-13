// 盒子启动互斥：连续 start、启动中停止、失败后重试，状态与返回值一致。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/box/box_start_lock.dart';

void main() {
  test('已在运行时再次 start 返回 null，不开第二条流程', () async {
    final lock = BoxStartLock();
    var bodies = 0;
    final first = await lock.run(
      alreadyRunning: true,
      body: (_) async {
        bodies++;
        return 'should-not-run';
      },
    );
    expect(first, isNull);
    expect(bodies, 0);
  });

  test('连续 start 共用一次流程，最终 running 与返回值一致', () async {
    final lock = BoxStartLock();
    var bodies = 0;
    var running = false;
    final entered = Completer<void>();
    final release = Completer<void>();

    Future<String?> body(int epoch) async {
      bodies++;
      entered.complete();
      await release.future;
      if (!lock.isCurrent(epoch)) return '已停止';
      running = true;
      return null;
    }

    final a = lock.run(alreadyRunning: running, body: body);
    await entered.future;
    final b = lock.run(alreadyRunning: running, body: body);
    expect(lock.isBusy, isTrue);
    release.complete();
    expect(await a, isNull);
    expect(await b, isNull);
    expect(bodies, 1);
    expect(running, isTrue);
  });

  test('启动中停止：进行中的流程不能提交，只能清自己的资源', () async {
    final lock = BoxStartLock();
    final owned = <String>[];
    final closed = <String>[];
    final entered = Completer<void>();
    final afterCancel = Completer<void>();

    final start = lock.run(
      alreadyRunning: false,
      body: (epoch) async {
        owned.add('db-$epoch');
        entered.complete();
        await afterCancel.future;
        if (!lock.isCurrent(epoch)) {
          closed.add(owned.removeLast());
          return '已停止';
        }
        return null;
      },
    );

    await entered.future;
    lock.cancel();
    afterCancel.complete();
    expect(await start, '已停止');
    expect(owned, isEmpty);
    expect(closed, ['db-1']);
    expect(lock.isCurrent(1), isFalse);
  });

  test('失败流程不能关掉另一次有效启动占用的资源', () async {
    final lock = BoxStartLock();
    final closed = <String>[];
    var running = false;
    String? liveDb;

    final firstEntered = Completer<void>();
    final firstRelease = Completer<void>();
    final first = lock.run(
      alreadyRunning: running,
      body: (epoch) async {
        liveDb = 'db-ok';
        firstEntered.complete();
        await firstRelease.future;
        if (!lock.isCurrent(epoch)) {
          closed.add(liveDb!);
          liveDb = null;
          return '已停止';
        }
        running = true;
        return null;
      },
    );
    await firstEntered.future;

    // 启动中的第二次应加入第一次，而不是自己再开库。
    final second = lock.run(
      alreadyRunning: running,
      body: (epoch) async {
        liveDb = 'db-other';
        return 'should-not-run';
      },
    );
    firstRelease.complete();
    expect(await first, isNull);
    expect(await second, isNull);
    expect(running, isTrue);
    expect(liveDb, 'db-ok');
    expect(closed, isEmpty);

    // 失败重试：新 epoch 失败时只关自己的库。
    running = false;
    final failed = await lock.run(
      alreadyRunning: running,
      body: (epoch) async {
        final mine = 'db-fail-$epoch';
        closed.add(mine);
        return '开盒子失败：端口占用';
      },
    );
    expect(failed, '开盒子失败：端口占用');
    expect(liveDb, 'db-ok');
    expect(closed, ['db-fail-2']);
  });
}
