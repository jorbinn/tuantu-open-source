import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/feed_player_load.dart';

void main() {
  test('同一代加载时连点重试会被拒绝', () {
    final lock = FeedPlayerLoadLock();
    expect(lock.begin(), 1);
    expect(lock.begin(), isNull);
    expect(lock.loading, isTrue);
  });

  test('初始化失败后可以再试，强制切媒体会作废旧代', () {
    final lock = FeedPlayerLoadLock();
    final first = lock.begin()!;
    lock.finish(first);
    expect(lock.loading, isFalse);
    expect(lock.begin(), 2);
    lock.invalidate();
    expect(lock.belongs(2), isFalse);
    expect(lock.begin(force: true), 4);
  });

  test('慢初始化完成时如果已经销毁/切走，会丢掉并释放', () async {
    final lock = FeedPlayerLoadLock();
    final ticket = lock.begin()!;
    final disposed = <String>[];
    lock.invalidate();
    final kept = await adoptLoaded(
      'player',
      ticket: ticket,
      currentGen: () => lock.gen,
      dispose: (v) async => disposed.add(v),
    );
    expect(kept, isNull);
    expect(disposed, ['player']);
  });

  test('快速切换时旧异步结果不能覆盖新控制器', () async {
    final lock = FeedPlayerLoadLock();
    final a = lock.begin(force: true)!;
    final b = lock.begin(force: true)!;
    expect(a, isNot(b));
    final assigned = <String>[];
    final keptA = await adoptLoaded(
      'old',
      ticket: a,
      currentGen: () => lock.gen,
      dispose: (v) async {},
    );
    final keptB = await adoptLoaded(
      'new',
      ticket: b,
      currentGen: () => lock.gen,
      dispose: (v) async {},
    );
    if (keptA != null) assigned.add(keptA);
    if (keptB != null) assigned.add(keptB);
    expect(assigned, ['new']);
  });
}
